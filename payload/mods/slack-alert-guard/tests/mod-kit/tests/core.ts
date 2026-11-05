// Claude Code's core, standing in for a guard mod's tests (#1484): the tool.check chain over every
// plugin decides whether a call may run, with the call's id and its arguments as the permission
// decision reads them, and a refusal reaches the call as an errored result. A mod's tests use a byte
// for byte copy of this file under their tests/mod-kit/tests, held to this one by
// tools/check-mod-shared-parts.sh, which also fails a test that raises the chain its own way.
//
// Which side raises the chain depends on the build. 2.1.304's test kit ran a $.tool.call straight
// into the tool.call hooks, so the stand-in raised the chain there. 2.1.307's kit raises it itself
// before any tool.call hook, and only an allowed call reaches them (measured 2026-10-22 with a probe
// mod on both builds). Raising it again judged every call twice, and spent a one time approval on
// the first judgement. So the rules beneath every plugin's tool.check hook note each call the kit
// checked, and the stand-in raises the chain only for a call they did not see.
//
// A call the kit checked is told from a test's own $.tool.check by its tool_use_id key: the kit's
// check of a call carries one, even for a call raised with none (undefined), and a query names none.
import type { On } from 'claude-code'
import type { Engine } from 'claude-code/testing'

export type Verdict = { decision: string; reason?: string }
export type CoreCall = { tool: string; id: string | undefined; input: Record<string, unknown> }
export type CoreRefusal = { isError: true; result: string | undefined; text: string }

// One call's identity, its keys sorted at every depth so the same call reads the same either side.
const stable = (v: unknown): unknown =>
  Array.isArray(v)
    ? v.map(stable)
    : v !== null && typeof v === 'object'
      ? Object.fromEntries(Object.keys(v as object).sort().map(k => [k, stable((v as Record<string, unknown>)[k])]))
      : v
const keyOf = (tool: unknown, id: unknown, input: unknown) => JSON.stringify([String(tool), id === undefined ? null : String(id), stable(input ?? {})])
const bump = (m: Map<string, number>, k: string, by: number) => {
  const n = (m.get(k) ?? 0) + by
  if (n > 0) m.set(k, n)
  else m.delete(k)
}

// Seats the rules beneath every plugin's tool.check hook (they allow every call unless `beneath`
// refuses it, as a settings hook can) and gives back the gate a tool.call stand-in asks first: the
// call as the tool would run it, or the refusal it is answered with.
export const standInCore = (engine: Engine, on: On, beneath: (e: unknown) => Verdict = () => ({ decision: 'allow' })) => {
  const checked = new Map<string, number>()
  const raising = new Map<string, number>()
  on('tool.check', ($, e) => {
    const x = e as unknown as Record<string, unknown>
    const verdict = beneath(e)
    const k = keyOf(x.tool, x.tool_use_id, x.input)
    if (verdict.decision !== 'deny' && !raising.has(k) && Object.prototype.hasOwnProperty.call(x, 'tool_use_id')) bump(checked, k, 1)
    return verdict as never
  })
  return async (e: unknown): Promise<{ call: CoreCall } | { refused: CoreRefusal }> => {
    const { tool, tool_use_id: id, agentId: _a, consent: _c, ...input } = e as Record<string, unknown>
    const call: CoreCall = { tool: String(tool), id: id === undefined ? undefined : String(id), input }
    const k = keyOf(tool, id, input)
    // Checked by the kit already, and allowed, since a refused call never reaches a tool.call hook.
    if (checked.has(k)) {
      bump(checked, k, -1)
      return { call }
    }
    bump(raising, k, 1)
    let verdict: Verdict
    try {
      verdict = (await engine.tool.check({ tool: call.tool, input, ...(id === undefined ? {} : { tool_use_id: call.id }) } as never)) as Verdict
    } finally {
      bump(raising, k, -1)
    }
    // A refusal there reaches the call as core reports it, an errored result whose text is the reason.
    if (verdict.decision === 'deny') return { refused: { isError: true, result: verdict.reason, text: verdict.reason ?? 'denied' } }
    return { call }
  }
}

// The reason a refusal gives, in either form it reaches a test: Claude Code 2.1.307 reports a
// plugin's refusal as "Permission to use <tool> denied by plugin <name>: <reason>", and the stand-in
// above as the bare reason. Only the named mod's prefix comes off, so another plugin's refusal keeps
// its whole text and a test expecting this mod's reason fails on it, naming who refused.
export const reasonOf = (r: unknown, mod: string): string => {
  const x = (r ?? {}) as { deny?: string; text?: string }
  const said = x.deny ?? x.text ?? ''
  const m = /^Permission to use \S+ denied by plugin (.+?): /.exec(said)
  return m && m[1] === mod ? said.slice(m[0].length) : said
}
