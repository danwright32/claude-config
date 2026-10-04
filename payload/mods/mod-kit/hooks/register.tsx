import type { Register } from 'claude-code'
import type { ModKit, ModKitBlocked } from '../types/index.d.ts'

// What every mod draws the same way (claude-config milestone 18, docs/mods-design.md), in one
// place so no guard keeps its own copy (L613). Today: the grey card for a blocked action, settled
// with Dan in design rounds 1 and 3 on 2026-10-03. Grey, because a block is a notice Claude works
// around by itself and colour is kept for what Dan has to act on.
//
// A blocked call is recorded by its tool_use_id when the guard refuses it, and its result row is
// drawn as the card. Kept in memory: after a reload an earlier row is drawn as Claude Code's own
// error row again, which still carries the whole refusal.
const blocked = new Map<string, ModKitBlocked>()
const MAX = 500

export const register: Register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    const modkit: ModKit = {
      blocked: input => {
        if (!input.toolUseId) return
        blocked.set(input.toolUseId, input)
        // Bounded, so a long session cannot grow it without end; the oldest rows are long gone.
        if (blocked.size > MAX) blocked.delete(blocked.keys().next().value as string)
      },
    }
    return { ...built, modkit }
  })

  on('ui.render', { component: 'ToolResult' }, ($, e, next) => {
    const b = blocked.get(e.props.tool_use_id)
    if (!b) return next(e)
    const { Box, Text } = $.ui.resolve(e)
    return (
      <Box flexDirection="column" borderStyle="round" borderColor="gray" paddingX={1}>
        <Text bold>Blocked by {b.guard}</Text>
        <Text>{b.reason}</Text>
        {b.safeWay ? <Text dimColor>{b.safeWay}</Text> : null}
      </Box>
    )
  })
}
