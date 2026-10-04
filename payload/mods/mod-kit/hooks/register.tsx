import { read } from 'claude-code'
import type { Register } from 'claude-code'
import type { ModKit, ModKitBandLine, ModKitBandPart, ModKitBandRow, ModKitCard, ModKitRun } from '../types/index.d.ts'
import { compose, drop, isDivider, put, refusal } from './band.ts'
import { blockedCard, cardRefusal } from './card.ts'
import { commands, git } from './commands.ts'

// What every mod draws the same way (claude-config milestone 18, docs/mods-design.md), in one
// place so no guard keeps its own copy (L613). Among it: the boxed card a tool result row is drawn
// as, the shape settled with Dan for a blocked action in design rounds 1 and 3 on 2026-10-03, and
// opened to any mod's own tool result in #663. Its border is grey, because colour is kept for what
// Dan has to act on; a run in the title may carry a colour, such as a leading state word.
//
// A card is recorded by its tool_use_id when the mod's tool.call hook runs, and its result row is
// drawn as the card. Kept in memory: after a reload an earlier row is drawn as Claude Code's own
// row again, which still carries the whole text the model read.
const cards = new Map<string, ModKitCard>()
const MAX = 500
const keep = (card: ModKitCard) => {
  cards.set(card.toolUseId, card)
  // Bounded, so a long session cannot grow it without end; the oldest rows are long gone.
  if (cards.size > MAX) cards.delete(cards.keys().next().value as string)
}

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
        // A guard's refusal stands without its card, so a call with no id is drawn as Claude Code's error row.
        if (!input.toolUseId) return
        keep(blockedCard(input))
      },
      card: async input => {
        const why = cardRefusal(input)
        if (why) throw new Error(why)
        keep(input)
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
    const card = cards.get(e.props.tool_use_id)
    if (!card) return next(e)
    const { Box, Text } = $.ui.resolve(e)
    // Each run its own Text nested in the line's, so a line wraps as one piece of text.
    const runs = (rs: ModKitRun[]) =>
      rs.map((r, i) => (
        <Text key={String(i)} color={r.color} bold={r.bold} dimColor={r.dim}>
          {r.text}
        </Text>
      ))
    return (
      <Box flexDirection="column" borderStyle="round" borderColor="gray" paddingX={1}>
        <Text bold>{runs(card.title)}</Text>
        {card.lines.map((l, n) => (
          <Text key={String(n)}>{runs(l)}</Text>
        ))}
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
    const part = (row: ModKitBandRow, p: ModKitBandPart, i: number) => {
      const drawn =
        'button' in p ? (
          // The press reaches the publisher through its ui.press hook on this key; nothing to do here.
          <Button key={`${row.mod}:${p.button}`} label={p.label} hotkey={p.hotkey} plain={p.plain} onPress={() => undefined} />
        ) : (
          <Text key={String(i)} color={p.color} bold={p.bold} dimColor={p.dim} strikethrough={p.strikethrough} wrap="truncate-end">
            {p.text}
          </Text>
        )
      return p.indent ? (
        <Box key={`indent:${i}`} paddingLeft={p.indent}>
          {drawn}
        </Box>
      ) : (
        drawn
      )
    }
    // A divider is as wide as the band and cut at the edge of whatever frame it sits in.
    const line = (row: ModKitBandRow, l: ModKitBandLine, n: number) =>
      isDivider(l) ? (
        <Text key={String(n)} color="gray" wrap="truncate-end">
          {'\u2500'.repeat(Math.max(1, e.props.bodyColumns))}
        </Text>
      ) : (
        <Box key={String(n)} flexDirection="row">
          {l.map((p, i) => part(row, p, i))}
        </Box>
      )
    const drawRow = (row: ModKitBandRow) => {
      const key = `${row.mod}/${row.id}`
      const lines = row.lines.map((l, n) => line(row, l, n))
      const color = row.frame?.color ?? 'gray'
      if (row.frame?.kind === 'box')
        return (
          <Box key={key} flexDirection="column" borderStyle="round" borderColor={color} paddingX={1}>
            {lines}
          </Box>
        )
      if (row.frame?.kind === 'left-rule')
        // One rule mark per line, since every line is one terminal line (text is cut, never wrapped).
        return (
          <Box key={key} flexDirection="row">
            <Box key={`${key}:rule`} flexDirection="column">
              {row.lines.map((_, n) => (
                <Text key={String(n)} color={color}>
                  {'\u2502'}
                </Text>
              ))}
            </Box>
            <Box flexDirection="column" paddingLeft={1} flexGrow={1}>
              {lines}
            </Box>
          </Box>
        )
      return (
        <Box key={key} flexDirection="column">
          {lines}
        </Box>
      )
    }
    return <Box flexDirection="column">{rows.map(drawRow)}</Box>
  })
}
