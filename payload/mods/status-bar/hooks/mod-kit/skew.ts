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
export const PROVIDERS: Readonly<Record<string, string>> = { modkit: 'mod-kit', jobs: 'job-watcher', sessions: 'session-registry', statusbar: 'status-bar' }
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

/**
 * An error as words: its message, or for a skew the one sentence, so every message a mod builds
 * from a failure it caught names the skew and the remedy. An absent noun keeps its own message,
 * since what absence means is each caller's rule.
 */
export const errorText = (err: unknown, mod: string): string => {
  const m = missingOf(err)
  if (m?.kind === 'member') return skewSentence(mod, m)
  if (isFailure(err)) return failureMessage(err)
  return String((err as Error)?.message ?? err)
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
