import { expect, test } from 'claude-code/testing'
import type { On } from 'claude-code'

// The resume line Claude opens with after an amendment is drawn as one dim grey line (design
// round, docs/mods-design.md row "Add-on notes (#620)"); the rest of the reply is Claude Code's own.

const engineDraws = (on: On) =>
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>{`engine:${String((e.props as { text?: string }).text ?? '')}`}</Text>
  })

const reply = (text: string, isFirstOfReply = true) =>
  ({ plugin: 'addon-notes', component: 'AssistantMessage' as const, props: { text, isFirstOfReply } }) as never

const LINE = '+ add-on: Adding a direct link to the commission and carrying on.'

for (const surface of ['terminal', 'desktop'] as const) {
  test(`the resume line is drawn dim above the reply on ${surface}`, async ($, on) => {
    engineDraws(on)
    const ui = await $.ui.mount({ ...(reply(`${LINE}\n\nThe link is in the footer now.`) as object), surface } as never)
    const line = await ui.find({ type: 'Text', text: LINE })
    expect(line?.type).toBe('Text')
    expect(line?.props.dimColor).toBe(true)
    // The rest is handed to Claude Code without the line, so it is not drawn twice.
    expect(await ui.find({ text: 'engine:The link is in the footer now.' })).toBeDefined()
    await ui.unmount()
  })
}

test('a reply that is only the resume line draws the line alone', async ($, on) => {
  engineDraws(on)
  const ui = await $.ui.mount({ ...(reply(LINE) as object), surface: 'terminal' } as never)
  expect((await ui.find({ type: 'Text', text: LINE }))?.props.dimColor).toBe(true)
  expect(await ui.find({ text: /^engine:/ })).toBeUndefined()
  await ui.unmount()
})

test('a reply without the resume line is left to Claude Code', async ($, on) => {
  engineDraws(on)
  const ui = await $.ui.mount({ ...(reply('Here is the plan.') as object), surface: 'terminal' } as never)
  expect(await ui.find({ text: 'engine:Here is the plan.' })).toBeDefined()
  await ui.unmount()
})

test('the line is only read at the opening of a reply, never from a later block', async ($, on) => {
  engineDraws(on)
  const ui = await $.ui.mount({ ...(reply(LINE, false) as object), surface: 'terminal' } as never)
  expect(await ui.find({ text: `engine:${LINE}` })).toBeDefined()
  await ui.unmount()
})
