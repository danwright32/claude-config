// A tool call's own arguments (#3190): the tool.call event without the keys Claude Code carries
// beside them. Eight mods took those keys off by hand, in twelve places, so a key the engine added had
// to be learned by every copy, and a copy that missed it would compare calls wrongly. Pure. Kept here once
// and copied byte for byte into each mod that asks it (hooks/mod-kit/toolargs.ts, which
// tools/check-mod-shared-parts.sh holds to this one, and which fails a mod naming the keys itself),
// since a mod cannot import another mod's files. requestMeta (#3219) is what a hook ahead may set for
// an MCP server, and Claude Code's own reading of a call's arguments takes it off with the other four.
// Since 2.1.327 a call's own argument named like one of those keys (an MCP tool taking `tool` or
// `consent`, say) is moved into $shadowed, and Claude Code's reading spreads it back when it is a plain
// object (#3256), so this does the same.

const isPlainObject = (v: unknown): v is Record<string, unknown> =>
  typeof v === 'object' && v !== null && !Array.isArray(v)

/** A call's own arguments: the tool.call event without the keys the engine carries beside them. */
export const toolArgs = (e: Record<string, unknown>): Record<string, unknown> => {
  const { tool: _t, tool_use_id: _i, agentId: _a, consent: _c, requestMeta: _m, $shadowed: shadowed, ...args } = e
  return isPlainObject(shadowed) ? { ...args, ...shadowed } : args
}
