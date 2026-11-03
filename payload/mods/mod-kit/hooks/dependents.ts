// #960, #966: which mods to load again after a mod they depend on reloads mid session. The reasons
// are in register.tsx beside askDependents, which reads the disk and calls these.

/** The mods a manifest's text names as its dependencies; throws when the text is not a manifest. */
export const dependsOn = (text: string): string[] => {
  const manifest = JSON.parse(text) as { dependencies?: unknown }
  const deps = manifest.dependencies ?? []
  if (!Array.isArray(deps) || deps.some(d => typeof d !== 'string')) throw new Error('its dependencies are not a list of mod names')
  return deps as string[]
}

/** The newest modification time among the files listed, 0 when there are none. */
export const newestFile = (entries: readonly { kind: string; mtimeMs: number }[]): number =>
  entries.reduce((max, e) => (e.kind === 'file' && e.mtimeMs > max ? e.mtimeMs : max), 0)

/**
 * Where each provider was last looked at (#966): `at` by provider, and `from` for one not looked at
 * yet (the session's start, or the first start of a mod-kit that looks).
 */
export type ProviderLook = { from: number; at: Readonly<Record<string, number>> }

/**
 * Which providers have reloaded by a turn's start, each with the time it was last looked at, and
 * where each is looked at from next. `newest` is each provider's newest file. One changed since its
 * last look has reloaded: a busy session reloads at its turn's end, an idle one at once. One whose
 * newest file is not older than the turn's start is still landing, and reloads at this turn's end,
 * so it is judged at the next look from the same time, and its dependents with it.
 */
export const judgeProviders = (newest: Readonly<Record<string, number>>, look: ProviderLook, turnStart: number) => {
  const reloaded = new Map<string, number>()
  const at: Record<string, number> = { ...look.at }
  for (const [provider, n] of Object.entries(newest)) {
    if (n >= turnStart) continue
    const since = look.at[provider] ?? look.from
    if (n > since) reloaded.set(provider, since)
    at[provider] = turnStart
  }
  return { reloaded, at }
}

/**
 * The providers among `deps` that reloaded while this mod may have been built against their old
 * version: each one the mod changed after the last look at.
 */
export const reloadedUnder = (deps: readonly string[], newest: number, reloaded: ReadonlyMap<string, number>): string[] =>
  deps.filter(p => {
    const since = reloaded.get(p)
    return since !== undefined && newest > since
  })

// #2100: a mod's hold on its reload while it waits on work a reload would drop. The longest a hold
// may last: a compaction measured at 45 s on 2026-11-02 and the status bar's own give up at ten
// minutes both fit well inside it, and a copy cancelled before it let go holds nothing back past it.
export const HOLD_MAX_MS = 60 * 60_000
export type Hold = { mod: string; id: string; what: string; until: number }

// Why a hold is refused, or undefined when it may be taken.
export const holdRefusal = (input: { mod?: unknown; id?: unknown; what?: unknown; ms?: unknown }): string | undefined => {
  for (const part of ['mod', 'id', 'what'] as const) {
    const v = input[part]
    if (typeof v !== 'string' || !v.trim()) return `a hold needs a ${part}, and was given ${JSON.stringify(v ?? null)}`
  }
  const ms = input.ms
  if (typeof ms !== 'number' || !Number.isFinite(ms) || ms <= 0 || ms > HOLD_MAX_MS) return `a hold lasts more than 0 ms and at most ${HOLD_MAX_MS} ms, and was given ${JSON.stringify(ms ?? null)}`
  return undefined
}

// The holds kept, with this one taken or renewed in place of any under the same mod and id.
export const withHold = (holds: readonly Hold[], hold: Hold): Hold[] => [...holds.filter(h => !(h.mod === hold.mod && h.id === hold.id)), hold]
export const withoutHold = (holds: readonly Hold[], mod: string, id: string): Hold[] => holds.filter(h => !(h.mod === mod && h.id === id))

// A mod's holds at `now`: those still holding its reload back, and those past their time.
export const holdsOf = (holds: readonly Hold[], mod: string, now: number) => ({
  live: holds.filter(h => h.mod === mod && h.until > now),
  expired: holds.filter(h => h.mod === mod && h.until <= now),
})
