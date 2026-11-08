// A call to another mod's noun that failed because the noun or the member is not there (#1281).
//
// A mod calls another mod's noun ($.modkit, $.scopeModes, $.isItLive, ...) as that other mod is
// loaded in this session. Measured on Claude Code 2.1.302 with two throwaway mods in a headless
// session that hot reloads (the measurement is in the PR for #1281):
//   - A mod reloaded BEFORE the mod it depends on keeps the older one's members until it loads
//     again. The provider reloading afterwards does not reach it, so a member added since throws
//     "$.<noun>.<member> is not a function" at the call site, on every call. Reloaded after the
//     provider, it sees the new members at once.
//   - mod-kit's own pass (#960), which touches such a mod's manifest when mod-kit reloads, does load
//     it again, but only once the session is idle: a session kept busy (an overnight worker whose
//     every Stop the driver blocks) keeps the stale copy for as long as it stays busy.
//   - A noun no loaded mod provides throws "undefined is not an object (evaluating
//     '$.<noun>.<member>')", which is that mod being absent, a different cause (L11).
// A hook that lets such a throw escape is skipped, and Claude Code says so once per load. What
// spoke on every call was each mod's own catch, rendering the TypeError into a toast or a refusal.
//
// So this is the one reader of that failure, used by every mod that calls another's noun, and
// the one sentence that names it and the remedy. It cannot be a member of mod-kit's noun: it is
// needed exactly when mod-kit's loaded copy is the older one. So each such mod keeps a copy of this
// file at hooks/mod-kit/skew.ts, byte for byte, which tools/check-mod-shared-parts.sh holds to this
// one, and no mod reads a TypeError by hand (the same tool's missing-reader rule).

/** A noun or member a mod called that this session's copy of the providing mod does not have. */
export type Missing = {
  /** `member`: the mod is loaded but its copy lacks the member (a skew). `noun`: no loaded mod provides the noun. */
  kind: 'member' | 'noun'
  noun: string
  member: string
  /** The providing mod's folder name, as Dan sees it. */
  provider: string
}

// The runtime's own words (JavaScriptCore, the same under `claude plugin test` and in a session):
//   member: "$.modkit.mergeHelper is not a function. (In '$.modkit.mergeHelper(c)', '$.modkit.mergeHelper' is undefined)"
//   noun:   "undefined is not an object (evaluating '$.isItLive.verdict')"
// The engine requires $ spelled in place at every call (`$.noun.member(...)`), so the call site's
// own text names both, whatever the mod's source called them.
const MEMBER = /^\$\.([A-Za-z_]\w*)\.([A-Za-z_]\w*) is not a function/
const NOUN = /^undefined is not an object \(evaluating '\$\.([A-Za-z_]\w*)\.([A-Za-z_]\w*)'\)/

// A noun is its mod's name in camel case, but for these. tests/test-mods.sh holds this to the noun
// every mod's own contract declares (types/index.d.ts), so a noun added or renamed under another
// name fails there rather than naming a mod that does not exist.
export const PROVIDERS: Readonly<Record<string, string>> = { modkit: 'mod-kit', jobs: 'job-watcher', sessions: 'session-registry', statusbar: 'status-bar', designRound: 'design-round-guard' }
const providerOf = (noun: string) => PROVIDERS[noun] ?? noun.replace(/[A-Z]/g, c => `-${c.toLowerCase()}`)

// A guard's .catch handler reads why its hook failed as plain data (`next.error`, the engine's
// HookFailure), the thrown error's message without its class (measured on 2.1.302:
// {"kind":"throw","message":"$.prov.b is not a function. (In '$.prov.b()', '$.prov.b' is undefined)","budget":1000}).
type Failure = { kind: string; message?: unknown }
const isFailure = (x: unknown): x is Failure => !!x && typeof x === 'object' && !(x instanceof Error) && typeof (x as Failure).kind === 'string'
const failureMessage = (f: Failure) => (typeof f.message === 'string' ? f.message : f.kind === 'timeout' ? 'it ran out of time' : `it failed (${f.kind})`)

/**
 * What is missing, when `err` is a call to another mod's noun that failed because it is not there
 * (a thrown TypeError, or a hook's failure as its .catch handler reads it); null for anything else.
 */
export const missingOf = (err: unknown): Missing | null => {
  const text = err instanceof TypeError ? String(err.message) : isFailure(err) && err.kind === 'throw' && typeof err.message === 'string' ? err.message : null
  if (text === null) return null
  const m = MEMBER.exec(text) ?? NOUN.exec(text)
  if (!m) return null
  const [, noun, member] = m as unknown as [string, string, string]
  return { kind: m.input.startsWith('$') ? 'member' : 'noun', noun, member, provider: providerOf(noun) }
}

/** The one sentence a skew is told in, to Dan and to Claude: both mods, the member, and the remedy. */
export const skewSentence = (mod: string, m: Missing): string =>
  `${mod} and ${m.provider} are out of step in this session: the ${m.provider} loaded here has no ${m.member}, which ${mod} needs, so a mod was updated after this session loaded it. A new session loads them together.`

// A call the engine refused or that failed arrives led by the engine's own name for it, shorthand
// Dan cannot read (#2150). Two shapes are measured: a refusal, "<mod>: $.fs.read: <reason>" (a
// test's deny and the real engine's denied reads), and a failure, "<mod>: $.fs.stat(<path>) failed:
// <reason>" (the real engine, 2026-11-01). An abandoned command's "<mod>: $.process.run(mkdir)
// aborted" has no reason after it and is left as it is: /sleep reads it as abandoned (#1677).
const ENGINE_HEAD = /^[a-z0-9][\w-]*: \$\.([A-Za-z_]\w*)\.([A-Za-z_]\w*)/
const FAILED = ') failed: '
// A system error as Node and the engine spell it: its code, then optionally its own words and, for a
// file, the call and the path ("EACCES: permission denied, open '/p'").
const SYSTEM_ERROR = /^(E[A-Z0-9]{2,})(?::\s*([\s\S]*))?$/
const BARE_CODE = /^E[A-Z0-9]{2,}$/
const SYSCALL_PATH = /^[^,]*, [a-z_]+ '([^']*)'(?: -> '[^']*')?$/

type EngineCall = { noun: string; member: string; arg: string | undefined; reason: string }

/** The path a system error's own words name, or null when they name none. */
const reasonPath = (reason: string): string | null => {
  const sys = SYSTEM_ERROR.exec(reason.trim())
  if (!sys) return null
  const detail = (sys[2] ?? '').trim()
  return SYSCALL_PATH.exec(detail)?.[1] ?? (detail.startsWith('/') || detail.startsWith('~') ? detail : null)
}

/**
 * An engine call's name, argument and reason, or null when the text is not one. The words
 * ") failed: " can sit in the path ("/tmp/a) failed: b/job.log"), in the reason (a path it quotes),
 * or in both, so neither the first nor the last of them is where the argument ends (#2328). Each
 * place they occur is a possible end, and the reason is read by the engine's known reason shapes,
 * a system error: first an end whose reason names the argument as its own path, then one whose
 * reason is a bare code (the shape the real engine gives, 2026-11-01), then the first whose reason
 * is a system error at all, which keeps a reason quoting the words whole. A reason in no known
 * shape cannot say where it starts, and keeps the last end, as #2367 read it.
 */
const engineCall = (text: string): EngineCall | null => {
  const head = ENGINE_HEAD.exec(text)
  if (!head) return null
  const [whole, noun, member] = head as unknown as [string, string, string]
  const rest = text.slice(whole.length)
  if (rest.startsWith(': ')) return { noun, member, arg: undefined, reason: rest.slice(2) }
  if (!rest.startsWith('(')) return null
  const ends: { arg: string; reason: string }[] = []
  for (let at = rest.indexOf(FAILED); at !== -1; at = rest.indexOf(FAILED, at + 1)) {
    ends.push({ arg: rest.slice(1, at), reason: rest.slice(at + FAILED.length) })
  }
  const known = ends.filter((e) => SYSTEM_ERROR.test(e.reason.trim()))
  const end =
    known.find((e) => reasonPath(e.reason) === e.arg) ??
    known.find((e) => BARE_CODE.test(e.reason.trim())) ??
    known[0] ??
    ends[ends.length - 1]
  return end ? { noun, member, ...end } : null
}

// What a file call could not do, in words. A call missing here keeps only its reason.
const CALL_WORDS: Readonly<Record<string, string>> = {
  'fs.read': 'the file could not be read',
  'fs.write': 'the file could not be written',
  'fs.stat': 'the file could not be looked up',
  'fs.exists': 'whether the file is there could not be checked',
  'fs.list': 'the folder could not be listed',
}

// Why, in words, for the codes a file call meets. A code missing here keeps the engine's own text
// for it, never a blank or a generic failure (L11).
const CODE_WORDS: Readonly<Record<string, string>> = {
  EACCES: 'permission denied',
  EPERM: 'the operation is not permitted',
  ENOENT: 'there is no such file or folder',
  ENOTDIR: 'a part of its path is not a folder',
  EISDIR: 'it is a folder, not a file',
  EEXIST: 'it already exists',
  ENOSPC: 'the disk is full',
  EROFS: 'the disk is read only',
  EBUSY: 'it is in use',
  EMFILE: 'too many files are open',
  ENFILE: 'too many files are open',
  ENAMETOOLONG: 'its name is too long',
  ELOOP: 'its path loops through links',
  ETIMEDOUT: 'it timed out',
}

/** An engine call's failure as plain words, or null when the text is not one. */
const engineWords = (text: string): string | null => {
  const call = engineCall(text)
  if (!call) return null
  const { noun, member, arg, reason } = call
  const sys = SYSTEM_ERROR.exec(reason.trim())
  const words = sys ? CODE_WORDS[sys[1] as string] : undefined
  let why = reason
  if (words !== undefined) {
    const detail = (sys?.[2] ?? '').trim()
    const path = SYSCALL_PATH.exec(detail)?.[1] ?? (detail.startsWith('/') || detail.startsWith('~') ? detail : arg)
    why = path ? `${words} (${path})` : words
  }
  const what = CALL_WORDS[`${noun}.${member}`]
  return what ? `${what}: ${why}` : why
}

const rawText = (err: unknown): string => (isFailure(err) ? failureMessage(err) : String((err as Error)?.message ?? err))

/**
 * An error as words: its message, or for a skew the one sentence, so every message a mod builds
 * from a failure it caught names the skew and the remedy. An engine call's failure is said in
 * plain words without the engine's name for the call (#2150). An absent noun keeps its own message,
 * since what absence means is each caller's rule.
 */
export const errorText = (err: unknown, mod: string): string => {
  const m = missingOf(err)
  if (m?.kind === 'member') return skewSentence(mod, m)
  const text = rawText(err)
  return engineWords(text) ?? text
}

/**
 * The system error code a failed call carries (ENOENT, EACCES, ...), or null: for a caller that
 * decides by the kind of failure, which the words errorText gives no longer spell.
 */
export const errorCode = (err: unknown): string | null => {
  const own = (err as { code?: unknown } | null | undefined)?.code
  if (typeof own === 'string' && /^E[A-Z0-9]{2,}$/.test(own)) return own
  if (err === undefined || err === null) return null
  const text = rawText(err)
  const reason = engineCall(text)?.reason ?? text
  return SYSTEM_ERROR.exec(reason.trim())?.[1] ?? null
}

// The skews already told in this load, by mod and member. A module of each mod's own copy, so it
// starts over when that mod loads again, which is when a skew can have mended.
const told = new Set<string>()

/** The sentence the first time this load meets this skew, for Dan to be told once; null after that, and for anything that is not a skew. */
export const skewNews = (err: unknown, mod: string): string | null => {
  const m = missingOf(err)
  if (m?.kind !== 'member') return null
  const key = `${mod}\u0000${m.noun}.${m.member}`
  if (told.has(key)) return null
  told.add(key)
  return skewSentence(mod, m)
}
