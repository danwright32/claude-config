import { read } from 'claude-code'
import type { Register } from 'claude-code'
import type { ModKit, ModKitBandPart, ModKitBandRow, ModKitBlocked } from '../types/index.d.ts'
import { compose, drop, put, refusal } from './band.ts'
import { commands, git } from './commands.ts'

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

// The band's rows, in $.state so a reload of this module keeps them (a module variable would not).
const band = { plugin: 'mod-kit', key: 'band' } as const

export const register: Register = (on, options) => {
  registerBand(on, options)
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    // Read, change and write the band with ifVersion, again on a miss, so two mods publishing at
    // once both land (assume it runs twice). The engine requires $ to be spelled in place, so this
    // cannot be the library's update(), which takes $ as an argument.
    const change = async (fn: (rows: ModKitBandRow[]) => ModKitBandRow[]) => {
      for (let attempt = 0; attempt < 10; attempt++) {
        const held = await built.state.get(band)
        const r = await built.state.set(band, fn(held.value ?? []), { ifVersion: held.version })
        if (r.isSet) return
      }
      throw new Error('the band changed under every one of 10 attempts to update it')
    }
    const modkit: ModKit = {
      blocked: async input => {
        if (!input.toolUseId) return
        blocked.set(input.toolUseId, input)
        // Bounded, so a long session cannot grow it without end; the oldest rows are long gone.
        if (blocked.size > MAX) blocked.delete(blocked.keys().next().value as string)
      },
      commands: async ({ command }) => commands(command),
      git: async ({ words }) => git(words),
      bandRow: async row => {
        const why = refusal(row)
        if (why) throw new Error(why)
        await change(rows => put(rows, row))
      },
      clearBandRow: async ({ mod, id }) => {
        await change(rows => drop(rows, mod, id))
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
        {b.note ? <Text dimColor>{b.note}</Text> : null}
      </Box>
    )
  })
}

// The band above the prompt: every mod's rows, in the settled order (hooks/band.ts). The one hook on
// it in any mod (tools/check-mod-shared-parts.sh). A survey holds the band, and the rows yield to it.
const registerBand: Register = on => {
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const rows = compose((await read($, band)) ?? [])
    if (e.props.hasSurvey || rows.length === 0) return next(e)
    const { Box, Button, Text } = $.ui.resolve(e)
    const part = (row: ModKitBandRow, p: ModKitBandPart, i: number) =>
      'button' in p ? (
        // The press reaches the publisher through its ui.press hook on this key; nothing to do here.
        <Button key={`${row.mod}:${p.button}`} label={p.label} hotkey={p.hotkey} onPress={() => undefined} />
      ) : (
        <Text key={String(i)} color={p.color} bold={p.bold} dimColor={p.dim} strikethrough={p.strikethrough} wrap="truncate-end">
          {p.text}
        </Text>
      )
    return (
      <Box flexDirection="column">
        {rows.map(row => (
          <Box key={`${row.mod}/${row.id}`} flexDirection="column">
            {row.lines.map((line, n) => (
              <Box key={String(n)} flexDirection="row">
                {line.map((p, i) => part(row, p, i))}
              </Box>
            ))}
          </Box>
        ))}
      </Box>
    )
  })
}
