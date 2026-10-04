import { read } from 'claude-code'
import type { EngineInterface, Register, ResolveInput } from 'claude-code'
import type { ModKit, ModKitBandLine, ModKitBandPart, ModKitBandRow, ModKitCard, ModKitPane, ModKitRun } from '../types/index.d.ts'
import { compose, drop, isDivider, paneRefusal, put, refusal } from './band.ts'
import { blockedCard, cardRefusal } from './card.ts'
import { commands, git } from './commands.ts'
import { sendTwice } from './send.ts'

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
// What each mod's side pane shows (#690), there for the same reason.
const panes = { plugin: 'mod-kit', key: 'panes' } as const

export const register: Register = (on, options) => {
  registerBand(on, options)
  // Every mod's message to another session, tried once more when refused (hooks/send.ts). Only a
  // mod's: Claude's own SendMessage, and anything else, is left as it is.
  on('session.send', async ($, e, next) => {
    const origin = (e as unknown as { origin?: { kind?: string } }).origin
    if (origin?.kind !== 'plugin') return next(e)
    return sendTwice(() => next(e))
  })
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
    // The same for the panes. fn may throw a refusal, judged against the panes as they are now.
    const changePanes = async (fn: (held: ModKitPane[]) => ModKitPane[]) => {
      for (let attempt = 0; attempt < 10; attempt++) {
        const held = await built.state.get(panes)
        const r = await built.state.set(panes, fn(held.value ?? []), { ifVersion: held.version })
        if (r.isSet) return
      }
      throw new Error('the panes changed under every one of 10 attempts to update them')
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
      pane: async pane => {
        await changePanes(held => {
          const why = paneRefusal(pane, held)
          if (why) throw new Error(why)
          return put(held, pane)
        })
      },
      clearPane: async ({ mod, id }) => {
        await changePanes(held => drop(held, mod, id))
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


// One mod's card as the band and a side pane both draw it (#690): its lines, inside its frame.
// `columns` is how wide the site is, so a divider reaches its edge. The one drawing of a card, so
// the band and the pane cannot drift apart as cards gain shapes.
const drawCard = <E extends ResolveInput>($: EngineInterface, e: E, columns: number, row: ModKitPane) => {
  const { Box, Button, Text } = $.ui.resolve(e)
  const part = (p: ModKitBandPart, i: number) => {
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
  // A divider is as wide as the site and cut at the edge of whatever frame it sits in.
  const line = (l: ModKitBandLine, n: number) =>
    isDivider(l) ? (
      <Text key={String(n)} color="gray" wrap="truncate-end">
        {'─'.repeat(Math.max(1, columns))}
      </Text>
    ) : (
      <Box key={String(n)} flexDirection="row">
        {l.map(part)}
      </Box>
    )
  const key = `${row.mod}/${row.id}`
  const lines = row.lines.map(line)
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
              {'│'}
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

// The band above the prompt: every mod's rows, in the settled order (hooks/band.ts). The one hook on
// it in any mod (tools/check-mod-shared-parts.sh). A survey holds the band, and the rows yield to it.
// A side pane a mod published through $.modkit.pane is drawn here too, as the same card; one it did
// not publish is left to whoever draws it.
const registerBand: Register = on => {
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const rows = compose((await read($, band)) ?? [])
    if (e.props.hasSurvey || rows.length === 0) return next(e)
    const { Box } = $.ui.resolve(e)
    return <Box flexDirection="column">{rows.map(row => drawCard($, e, e.props.bodyColumns, row))}</Box>
  })
  on('ui.render', { component: 'Pane' }, async ($, e, next) => {
    const pane = ((await read($, panes)) ?? []).find(p => p.id === e.requestId)
    if (!pane) return next(e)
    return drawCard($, e, e.props.bodyColumns, pane)
  })
}
