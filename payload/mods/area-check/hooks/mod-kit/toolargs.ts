// A tool call's own arguments (#3190): the tool.call event without the keys Claude Code carries
// beside them. Eight mods took those keys off by hand, in twelve places, so a key the engine added had
// to be learned by every copy, and a copy that missed it would compare calls wrongly. Pure. Kept here once
// and copied byte for byte into each mod that asks it (hooks/mod-kit/toolargs.ts, which
// tools/check-mod-shared-parts.sh holds to this one, and which fails a mod naming the keys itself),
// since a mod cannot import another mod's files.

/** A call's own arguments: the tool.call event without the keys the engine carries beside them. */
export const toolArgs = (e: Record<string, unknown>): Record<string, unknown> => {
  const { tool: _t, tool_use_id: _i, agentId: _a, consent: _c, ...args } = e
  return args
}
